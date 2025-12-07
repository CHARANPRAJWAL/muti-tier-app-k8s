# Multi-Tier Application

A simple three-tier web application demonstrating the separation of concerns between frontend, backend, and database layers.

## Architecture

- **Frontend**: React (Port 3000)
- **Backend**: Node.js with Express (Port 5000)
- **Database**: PostgreSQL (Port 5432)

## Features

- Full CRUD operations for user management
- RESTful API design
- Responsive UI with React
- PostgreSQL database with proper schema
- Docker containerization for easy deployment
- Health check endpoints

## Project Structure

```
multi-tier-app/
├── backend/
│   ├── server.js          # Express server with API endpoints
│   ├── db.js              # PostgreSQL connection pool
│   ├── init.sql           # Database initialization script
│   ├── package.json       # Backend dependencies
│   ├── .env               # Environment variables
│   └── Dockerfile         # Backend container configuration
├── frontend/
│   ├── public/
│   │   └── index.html     # HTML template
│   ├── src/
│   │   ├── App.js         # Main React component
│   │   ├── App.css        # Application styles
│   │   ├── index.js       # React entry point
│   │   └── index.css      # Global styles
│   ├── package.json       # Frontend dependencies
│   └── Dockerfile         # Frontend container configuration
├── docker-compose.yml     # Multi-container orchestration
└── README.md              # This file
```

## Prerequisites

Choose one of the following options:

### Option 1: Docker (Recommended)
- Docker Desktop installed
- Docker Compose installed

### Option 2: Local Development
- Node.js (v18 or higher)
- PostgreSQL (v15 or higher)
- npm or yarn

## Quick Start with Docker

1. **Clone or navigate to the project directory**
   ```bash
   cd multi-tier-app
   ```

2. **Start all services**
   ```bash
   docker-compose up --build
   ```

3. **Access the application**
   - Frontend: http://localhost:3000
   - Backend API: http://localhost:5000/api
   - Health Check: http://localhost:5000/api/health

4. **Stop the application**
   ```bash
   docker-compose down
   ```

## Local Development Setup

### Backend Setup

1. **Navigate to backend directory**
   ```bash
   cd backend
   ```

2. **Install dependencies**
   ```bash
   npm install
   ```

3. **Setup PostgreSQL database**
   - Create a database named `appdb`
   - Run the initialization script:
   ```bash
   psql -U postgres -d appdb -f init.sql
   ```

4. **Configure environment variables**
   - Update `.env` file with your PostgreSQL credentials if needed

5. **Start the backend server**
   ```bash
   npm start
   ```
   Or for development with auto-reload:
   ```bash
   npm run dev
   ```

### Frontend Setup

1. **Navigate to frontend directory**
   ```bash
   cd frontend
   ```

2. **Install dependencies**
   ```bash
   npm install
   ```

3. **Start the development server**
   ```bash
   npm start
   ```

4. **Access the application**
   - Open http://localhost:3000 in your browser

## API Endpoints

### Users

- `GET /api/health` - Health check endpoint
- `GET /api/users` - Get all users
- `GET /api/users/:id` - Get user by ID
- `POST /api/users` - Create new user
  ```json
  {
    "name": "John Doe",
    "email": "john@example.com"
  }
  ```
- `PUT /api/users/:id` - Update user
  ```json
  {
    "name": "Jane Doe",
    "email": "jane@example.com"
  }
  ```
- `DELETE /api/users/:id` - Delete user

## Database Schema

### Users Table

| Column     | Type         | Constraints           |
|------------|--------------|----------------------|
| id         | SERIAL       | PRIMARY KEY          |
| name       | VARCHAR(100) | NOT NULL             |
| email      | VARCHAR(100) | NOT NULL, UNIQUE     |
| created_at | TIMESTAMP    | DEFAULT CURRENT_TIMESTAMP |

## Environment Variables

### Backend (.env)

```
PORT=5000
DB_HOST=localhost
DB_PORT=5432
DB_NAME=appdb
DB_USER=postgres
DB_PASSWORD=postgres
```

### Frontend

When using Docker, the API URL is configured in `docker-compose.yml`.
For local development, the proxy is configured in `package.json`.

## Troubleshooting

### Docker Issues

1. **Port already in use**
   - Stop any services running on ports 3000, 5000, or 5432
   - Or modify the port mappings in `docker-compose.yml`

2. **Database connection failed**
   - Wait for PostgreSQL to fully initialize (health check)
   - Check logs: `docker-compose logs postgres`

### Local Development Issues

1. **Cannot connect to database**
   - Ensure PostgreSQL is running
   - Verify credentials in `.env` file
   - Check if database `appdb` exists

2. **Frontend cannot reach backend**
   - Ensure backend is running on port 5000
   - Check CORS settings if accessing from different origin

## Production Considerations

For production deployment, consider:

- Use environment-specific configuration
- Implement proper authentication and authorization
- Add input validation and sanitization
- Use connection pooling efficiently
- Implement proper error logging
- Use HTTPS
- Add rate limiting
- Set up proper database backups
- Use production-ready Docker images
- Implement CI/CD pipeline

## License

This is a demonstration project for educational purposes.
